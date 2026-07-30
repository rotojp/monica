<?php

namespace App\Http\Resources;

use App\Helpers\DateHelper;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * @mixin \App\Models\ContactInformation
 */
class ContactInformationResource extends JsonResource
{
    /**
     * Transform the resource into an array.
     *
     * @param  \Illuminate\Http\Request  $request
     */
    public function toArray($request): array
    {
        // Deliberately not named `data`: a top-level `data` key in a resource
        // array suppresses Laravel's own `data` envelope on single resources,
        // which would make index and store responses differ in shape.
        return [
            'id' => $this->id,
            'kind' => $this->kind,
            'content' => $this->data,
            'contact_information_type' => $this->contactInformationType ? [
                'id' => $this->contactInformationType->id,
                'name' => $this->contactInformationType->name,
                'protocol' => $this->contactInformationType->protocol,
                'type' => $this->contactInformationType->type,
            ] : null,
            'created_at' => DateHelper::getTimestamp($this->created_at),
            'updated_at' => DateHelper::getTimestamp($this->updated_at),
        ];
    }
}
